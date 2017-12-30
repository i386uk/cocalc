###
Toggle whether or not to show tasks (deleted, done)
###

{React, rclass, rtypes}  = require('../smc-react')

{Icon, Space} = require('../r_misc')

misc = require('smc-util/misc')

exports.ShowToggle = rclass
    propTypes :
        actions : rtypes.object.isRequired
        type    : rtypes.string.isRequired
        count   : rtypes.number.isRequired
        show    : rtypes.bool

    shouldComponentUpdate: (next) ->
        return @props.show  != next.show or \
               @props.count != next.count or \
               @props.type  != next.type

    render_toggle: ->
        if @props.show
            name = 'check-square-o'
        else
            name = 'square-o'
        return <Icon name={name} />

    toggle_state: ->
        if @props.show
            @props.actions["stop_showing_#{@props.type}"]()
        else
            if @props.count == 0 # do nothing
                return
            @props.actions["show_#{@props.type}"]()

    render: ->
        toggle = @render_toggle()
        if not @props.actions?  # no support for toggling (e.g., history view)
            return toggle
        style = {cursor:'pointer'}
        if @props.count > 0  or @props.show
            style.color = '#333'
        else
            style.color = '#999'
        <div onClick={@toggle_state} style={style}>
            <span style={fontSize:'17pt'}>
                {toggle}
            </span>
            <Space />
            <span>
                Show {@props.type} ({@props.count})
            </span>
        </div>